#!/usr/bin/env bash
# Move o card de Issues no GitHub Project (V2) para um Status, resolvendo
# todos os IDs por nome via GraphQL.
#
# Uso:
#   scripts/project-status.sh --pr 12 --status "Draft PR" [--dry-run]
#   scripts/project-status.sh --issue 4 --status "Backlog" [--dry-run]
#
# Configuração (variáveis de ambiente):
#   PROJECT_OWNER      dono do Project (login do usuário ou da organização)  [obrigatória]
#   PROJECT_NUMBER     número do Project (ex.: 1)                             [obrigatória]
#   OWNER_TYPE         "user" (padrão) ou "organization"
#   GITHUB_REPOSITORY  "owner/repo" do PR/Issue (o Actions já define)         [obrigatória]
#   STATUS_FIELD       nome do campo de status (padrão: "Status")
#   LINK_RETRIES       tentativas quando o PR ainda não tem Issues vinculadas (padrão: 5)
#   LINK_RETRY_DELAY   segundos entre tentativas (padrão: 3)
#
# Requer apenas o GitHub CLI (`gh`) autenticado, com acesso ao Project
# (escopo `project`). Usa o `--jq` embutido no gh; não depende de `jq`.

set -euo pipefail

usage() { sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-1}"; }
log()   { echo "[project-status] $*"; }
fail()  { echo "[project-status] ERRO: $*" >&2; exit 1; }

PR="" ISSUE="" STATUS="" DRY_RUN=0
while [ $# -gt 0 ]; do
  case "$1" in
    --pr)      PR="${2:-}"; shift 2 ;;
    --issue)   ISSUE="${2:-}"; shift 2 ;;
    --status)  STATUS="${2:-}"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage 0 ;;
    *)         fail "argumento desconhecido: $1" ;;
  esac
done

[ -n "$STATUS" ] || fail "--status é obrigatório"
[ -n "$PR" ] || [ -n "$ISSUE" ] || fail "informe --pr ou --issue"
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
