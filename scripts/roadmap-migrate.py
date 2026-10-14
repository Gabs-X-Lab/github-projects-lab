#!/usr/bin/env python3
"""Importa o ROADMAP.md como Issues (e Draft Issues) no GitHub Project (V2).

Só importação: o ROADMAP.md não é alterado e não há sincronização depois.

Uso:
  scripts/roadmap-migrate.py [--file ROADMAP.md]            # simulação (não grava nada)
  scripts/roadmap-migrate.py [--file ROADMAP.md] --apply    # cria no GitHub

Formato lido (ver ROADMAP.md):
  ## Q4 2026 — MVP            → Milestone de mesmo título (precisa existir)
  ## Débitos técnicos         → label "tech-debt", sem milestone
  ## Sugestões ...            → cada "- texto" vira Draft Issue em "Sugestão"
  ### Autenticação            → label da área (AREA_LABELS)
  - [ ] Título 🔴 (M) @login  → Issue (Priority, Size, Assignee); Status "Backlog"
  - [ ] 🚧 Título             → Status "In Progress"
  - [x] Título                → Issue criada e fechada como concluída (nativo "Item closed" → Done)
    - [ ] Subitem             → sub-issue do item acima

Idempotente: cada Issue recebe um marcador oculto no corpo (<!-- roadmap: chave -->).
Na próxima execução, Issues com o marcador (ou, sem marcador, com o mesmo título) e
Draft Issues com o mesmo título são mantidas como estão.

Configuração (variáveis de ambiente, as mesmas do project-status.sh):
  PROJECT_OWNER, PROJECT_NUMBER, OWNER_TYPE ("user" | "organization"),
  GITHUB_REPOSITORY ("owner/repo")

Requer apenas Python 3 (biblioteca padrão) e o GitHub CLI (`gh`) autenticado
com acesso ao repositório e ao Project.
"""

import argparse
import json
import os
import re
import subprocess
import sys
import time
import unicodedata
from dataclasses import dataclass, field

# Seção "###" do ROADMAP.md → label. Seções "##" especiais são tratadas no parser.
AREA_LABELS = {
    "Autenticação": "area:auth",
    "Agenda": "area:agenda",
    "Pacientes": "area:pacientes",
    "Notificações": "area:notificacoes",
    "Dashboard": "area:dashboard",
    "Pagamentos": "area:pagamentos",
}
TECH_DEBT_SECTION, TECH_DEBT_LABEL = "Débitos técnicos", "tech-debt"
SUGGESTIONS_PREFIX = "Sugestões"
FEATURE_LABEL = "enhancement"  # itens que não são débito técnico

STATUS_FIELD, PRIORITY_FIELD, SIZE_FIELD = "Status", "Priority", "Size"
COL_SUGGESTION, COL_BACKLOG, COL_DEV = "Sugestão", "Backlog", "In Progress"
PRIORITY_EMOJIS = ("🔴", "🟡", "🟢")  # a opção do campo Priority começa com o emoji

MUTATION_DELAY = 0.7  # segundos entre criações (limite secundário de criação de conteúdo)


def log(msg):
    print(f"[roadmap-migrate] {msg}", flush=True)


def fail(msg):
    print(f"[roadmap-migrate] ERRO: {msg}", file=sys.stderr)
    sys.exit(1)


def slug(text):
    text = unicodedata.normalize("NFKD", text).encode("ascii", "ignore").decode()
    return re.sub(r"[^a-z0-9]+", "-", text.lower()).strip("-")


# ---------------------------------------------------------------------------
# Leitura do markdown (adaptador do formato; não acessa o GitHub)
# ---------------------------------------------------------------------------

@dataclass
class Item:
    title: str
    key: str
    done: bool = False
    in_progress: bool = False
    priority: str | None = None
    size: str | None = None
    assignee: str | None = None
    milestone: str | None = None
    labels: list = field(default_factory=list)
    section: str = ""
    children: list = field(default_factory=list)


CHECKBOX = re.compile(r"^(\s*)- \[([ xX])\] (.+)$")
BULLET = re.compile(r"^- (.+)$")


def parse_item_text(text):
    """'🚧 Login com Google (OAuth) 🔴 (M) @Gabs-X' → (título, 🚧?, prioridade, tamanho, login)."""
    in_progress = "🚧" in text
    priority = next((e for e in PRIORITY_EMOJIS if e in text), None)
    size = m.group(1) if (m := re.search(r"\(([PMG])\)", text)) else None
    assignee = m.group(1) if (m := re.search(r"@([A-Za-z0-9-]+)", text)) else None
    title = text.replace("🚧", "")
    for e in PRIORITY_EMOJIS:
        title = title.replace(e, "")
    title = re.sub(r"\(([PMG])\)|@[A-Za-z0-9-]+", "", title)
    return re.sub(r"\s+", " ", title).strip(), in_progress, priority, size, assignee


def parse_roadmap(path):
    """Devolve (itens, sugestões). Itens são hierárquicos (children = sub-issues)."""
    items, suggestions = [], []
    milestone = area_label = None
    section = ""
    mode = None  # None (antes do 1º "##"), "items" ou "suggestions"
    parent = None

    with open(path, encoding="utf-8") as f:
        for lineno, raw in enumerate(f, 1):
            line = raw.rstrip("\n")
            if line.startswith("## "):
                heading = line[3:].strip()
                parent, area_label = None, None
                if heading.startswith(SUGGESTIONS_PREFIX):
                    mode, milestone = "suggestions", None
                elif heading == TECH_DEBT_SECTION:
                    mode, milestone, area_label = "items", None, TECH_DEBT_LABEL
                else:
                    mode, milestone = "items", heading
                section = heading
                continue
            if line.startswith("### ") and mode == "items":
                name = line[4:].strip()
                area_label = AREA_LABELS.get(name)
                if area_label is None:
                    log(f"aviso: linha {lineno}: seção '{name}' sem label em AREA_LABELS")
                section = f"{milestone} / {name}" if milestone else name
                parent = None
                continue

            if mode == "suggestions" and (m := BULLET.match(line)):
                suggestions.append(m.group(1).strip())
            elif mode == "items" and (m := CHECKBOX.match(line)):
                indent, mark, text = m.groups()
                title, in_progress, priority, size, assignee = parse_item_text(text)
                is_child = len(indent) > 0
                if is_child and parent is None:
                    fail(f"linha {lineno}: subitem sem item pai")
                prefix = parent.key if is_child else "/".join(
                    slug(p) for p in (milestone or TECH_DEBT_LABEL, section.split(" / ")[-1]))
                labels = [area_label] if area_label else []
                if area_label != TECH_DEBT_LABEL:
                    labels.append(FEATURE_LABEL)
                item = Item(
                    title=title, key=f"{prefix}/{slug(title)}", done=mark.lower() == "x",
                    in_progress=in_progress, priority=priority, size=size, assignee=assignee,
                    milestone=milestone, labels=labels, section=section)
                if is_child:
                    parent.children.append(item)
                else:
                    items.append(item)
                    parent = item
    return items, suggestions


# ---------------------------------------------------------------------------
# GitHub (GraphQL via gh)
# ---------------------------------------------------------------------------

class GraphQLError(Exception):
    pass


def gql(query, _raise=False, **variables):
    """Executa a consulta. Em erro: encerra o script, ou levanta GraphQLError se _raise=True."""
    body = json.dumps({"query": query, "variables": variables})
    proc = subprocess.run(["gh", "api", "graphql", "--input", "-"], input=body.encode("utf-8"),
                          capture_output=True)
    out = proc.stdout.decode("utf-8") or "{}"
    data = json.loads(out)
    if proc.returncode != 0 or data.get("errors"):
        msg = "; ".join(e.get("message", "") for e in data.get("errors", [])) or proc.stderr.decode("utf-8").strip()
        if _raise:
            raise GraphQLError(msg)
        fail(f"GraphQL: {msg}")
    return data["data"]


def paginate(query, path, **variables):
    """Percorre uma conexão GraphQL (pageInfo/nodes) indicada por 'path' (ex.: 'repository.issues')."""
    after = None
    while True:
        node = gql(query, after=after, **variables)
        for part in path.split("."):
            node = node[part]
        yield from node["nodes"]
        if not node["pageInfo"]["hasNextPage"]:
            return
        after = node["pageInfo"]["endCursor"]


class GitHub:
    def __init__(self, repo, project_owner, project_number, owner_type, apply):
        self.owner, self.name = repo.split("/")
        self.apply = apply
        self.project_owner, self.project_number, self.owner_type = project_owner, project_number, owner_type
        self._users = {}
        self._load()

    def _load(self):
        r = gql("""
          query($owner: String!, $name: String!) {
            repository(owner: $owner, name: $name) {
              id
              labels(first: 100) { nodes { id name } }
              milestones(first: 100, states: [OPEN, CLOSED]) { nodes { id title } }
            }
          }""", owner=self.owner, name=self.name)["repository"]
        self.repo_id = r["id"]
        self.labels = {n["name"]: n["id"] for n in r["labels"]["nodes"]}
        self.milestones = {n["title"]: n["id"] for n in r["milestones"]["nodes"]}

        p = gql(f"""
          query($owner: String!, $number: Int!) {{
            {self.owner_type}(login: $owner) {{
              projectV2(number: $number) {{
                id
                fields(first: 50) {{ nodes {{ ... on ProjectV2SingleSelectField {{ id name options {{ id name }} }} }} }}
              }}
            }}
          }}""", owner=self.project_owner, number=self.project_number)[self.owner_type]["projectV2"]
        if not p:
            fail(f"Project {self.project_owner}/{self.project_number} não encontrado (ou sem acesso)")
        self.project_id = p["id"]
        self.fields = {f["name"]: f for f in p["fields"]["nodes"] if f}
        for name in (STATUS_FIELD, PRIORITY_FIELD, SIZE_FIELD):
            if name not in self.fields:
                fail(f"campo '{name}' não encontrado no Project")

    def option(self, field_name, match):
        """ID da opção: nome exato, ou (Priority) nome começando pelo emoji."""
        for o in self.fields[field_name]["options"]:
            if o["name"] == match or (field_name == PRIORITY_FIELD and o["name"].startswith(match)):
                return o["id"]
        fail(f"opção '{match}' não existe no campo '{field_name}'")

    def user_id(self, login):
        if login not in self._users:
            u = gql("query($login: String!) { user(login: $login) { id } }", login=login)["user"]
            if not u:
                fail(f"usuário @{login} não encontrado")
            self._users[login] = u["id"]
        return self._users[login]

    def existing_issues(self):
        """(marcador → número, título → número) de todas as Issues do repositório."""
        by_key, by_title = {}, {}
        for n in paginate("""
          query($owner: String!, $name: String!, $after: String) {
            repository(owner: $owner, name: $name) {
              issues(first: 100, after: $after, states: [OPEN, CLOSED]) {
                pageInfo { hasNextPage endCursor }
                nodes { number title body }
              }
            }
          }""", "repository.issues", owner=self.owner, name=self.name):
            if m := re.search(r"<!-- roadmap: (\S+) -->", n["body"] or ""):
                by_key[m.group(1)] = n["number"]
            else:
                by_title.setdefault(n["title"], n["number"])
        return by_key, by_title

    def existing_drafts(self):
        return {n["content"]["title"] for n in paginate(f"""
          query($owner: String!, $number: Int!, $after: String) {{
            {self.owner_type}(login: $owner) {{
              projectV2(number: $number) {{
                items(first: 100, after: $after) {{
                  pageInfo {{ hasNextPage endCursor }}
                  nodes {{ content {{ ... on DraftIssue {{ title }} }} }}
                }}
              }}
            }}
          }}""", f"{self.owner_type}.projectV2.items", owner=self.project_owner, number=self.project_number)
            if n["content"] and "title" in n["content"]}

    # --- escrita -----------------------------------------------------------

    def create_issue(self, item, body):
        missing = [l for l in item.labels if l not in self.labels]
        if missing:
            fail(f"labels inexistentes no repositório: {missing}")
        if item.milestone and item.milestone not in self.milestones:
            fail(f"milestone '{item.milestone}' não existe no repositório")
        issue = gql("""
          mutation($input: CreateIssueInput!) { createIssue(input: $input) { issue { id number } } }""",
                    input={
                        "repositoryId": self.repo_id, "title": item.title, "body": body,
                        "labelIds": [self.labels[l] for l in item.labels],
                        "milestoneId": self.milestones.get(item.milestone),
                        "assigneeIds": [self.user_id(item.assignee)] if item.assignee else [],
                    })["createIssue"]["issue"]
        time.sleep(MUTATION_DELAY)
        return issue

    def add_to_project(self, content_id):
        # Não espera o Auto-add (tem atraso). Se o Auto-add chegar primeiro, a mutation
        # falha com "Content already exists in this project": busca o item pela Issue.
        try:
            return gql("""
              mutation($project: ID!, $content: ID!) {
                addProjectV2ItemById(input: { projectId: $project, contentId: $content }) { item { id } }
              }""", _raise=True, project=self.project_id, content=content_id)["addProjectV2ItemById"]["item"]["id"]
        except GraphQLError as e:
            if "already exists" not in str(e):
                fail(f"GraphQL: {e}")
        nodes = gql("""
          query($id: ID!) { node(id: $id) { ... on Issue { projectItems(first: 20) { nodes { id project { id } } } } } }""",
                    id=content_id)["node"]["projectItems"]["nodes"]
        item = next((n["id"] for n in nodes if n["project"]["id"] == self.project_id), None)
        if not item:
            fail("item informado como existente, mas não encontrado no Project")
        return item

    def set_option(self, item_id, field_name, option_id):
        gql("""
          mutation($project: ID!, $item: ID!, $field: ID!, $option: String!) {
            updateProjectV2ItemFieldValue(input: {
              projectId: $project, itemId: $item, fieldId: $field, value: { singleSelectOptionId: $option }
            }) { projectV2Item { id } }
          }""", project=self.project_id, item=item_id, field=self.fields[field_name]["id"], option=option_id)

    def status_of(self, item_id):
        node = gql(f"""
          query($id: ID!) {{
            node(id: $id) {{ ... on ProjectV2Item {{
              status: fieldValueByName(name: "{STATUS_FIELD}") {{ ... on ProjectV2ItemFieldSingleSelectValue {{ name }} }}
            }} }}
          }}""", id=item_id)["node"]
        return (node.get("status") or {}).get("name")

    def close_completed(self, issue_id):
        gql("""
          mutation($id: ID!) { closeIssue(input: { issueId: $id, stateReason: COMPLETED }) { issue { number } } }""",
            id=issue_id)

    def add_sub_issue(self, parent_id, child_id):
        gql("""
          mutation($parent: ID!, $child: ID!) {
            addSubIssue(input: { issueId: $parent, subIssueId: $child }) { issue { number } }
          }""", parent=parent_id, child=child_id)

    def create_draft(self, title, body):
        item = gql("""
          mutation($project: ID!, $title: String!, $body: String!) {
            addProjectV2DraftIssue(input: { projectId: $project, title: $title, body: $body }) { projectItem { id } }
          }""", project=self.project_id, title=title, body=body)["addProjectV2DraftIssue"]["projectItem"]
        time.sleep(MUTATION_DELAY)
        return item["id"]


# ---------------------------------------------------------------------------
# Importação
# ---------------------------------------------------------------------------

def describe(item):
    parts = [f"status={'Done (fechada)' if item.done else COL_DEV if item.in_progress else COL_BACKLOG}"]
    parts += [f"priority={item.priority}"] if item.priority else []
    parts += [f"size={item.size}"] if item.size else []
    parts += [f"@{item.assignee}"] if item.assignee else []
    parts += [f"milestone='{item.milestone}'"] if item.milestone else []
    parts += [f"labels={','.join(item.labels)}"]
    return " ".join(parts)


def import_items(gh, items, by_key, by_title, stats, pending_status, parent=None, depth=0):
    for item in items:
        indent = "  " * depth
        number = by_key.get(item.key) or by_title.get(item.title)
        issue_id = None
        if number:
            log(f"{indent}= #{number} já existe: {item.title}")
            stats["existentes"] += 1
        elif not gh.apply:
            log(f"{indent}+ [simulação] {item.title} | {describe(item)}")
            stats["criadas"] += 1
        else:
            body = (f"Importada do `ROADMAP.md` (seção *{item.section}*).\n\n"
                    f"<!-- roadmap: {item.key} -->")
            issue = gh.create_issue(item, body)
            issue_id, number = issue["id"], issue["number"]
            item_id = gh.add_to_project(issue_id)
            if item.priority:
                gh.set_option(item_id, PRIORITY_FIELD, gh.option(PRIORITY_FIELD, item.priority))
            if item.size:
                gh.set_option(item_id, SIZE_FIELD, gh.option(SIZE_FIELD, item.size))
            if parent:
                gh.add_sub_issue(parent, issue_id)
            if item.done:
                gh.close_completed(issue_id)  # o nativo "Item closed" leva a Done
            else:
                status = COL_DEV if item.in_progress else COL_BACKLOG
                gh.set_option(item_id, STATUS_FIELD, gh.option(STATUS_FIELD, status))
                pending_status.append((number, item_id, status))
            log(f"{indent}+ #{number} {item.title} | {describe(item)}")
            stats["criadas"] += 1
        if item.children:
            if number and not issue_id and gh.apply:
                # pai já existia: só os filhos novos são criados (e não ficam como sub-issue)
                log(f"{indent}  aviso: pai #{number} já existia; subitens novos não serão vinculados como sub-issues")
            import_items(gh, item.children, by_key, by_title, stats, pending_status, issue_id, depth + 1)


def verify_status(gh, pending, rounds=3, delay=5):
    """Os workflows nativos (Item added / Auto-add) rodam de forma assíncrona e podem
    sobrescrever o Status logo depois da criação. Confere e corrige."""
    for _ in range(rounds):
        if not pending:
            return
        time.sleep(delay)
        wrong = [(n, i, s) for n, i, s in pending if gh.status_of(i) != s]
        for number, item_id, status in wrong:
            log(f"#{number}: Status alterado depois da criação; reaplicando '{status}'")
            gh.set_option(item_id, STATUS_FIELD, gh.option(STATUS_FIELD, status))
        pending = wrong
    if pending:
        log(f"aviso: Status não confirmado para {[n for n, _, _ in pending]}")


def main():
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8")
        sys.stderr.reconfigure(encoding="utf-8")
    ap = argparse.ArgumentParser(description="Importa o ROADMAP.md como Issues no GitHub Project.")
    ap.add_argument("--file", default="ROADMAP.md")
    ap.add_argument("--apply", action="store_true", help="grava no GitHub (sem isso, só simula)")
    args = ap.parse_args()

    env = {k: os.environ.get(k) for k in ("PROJECT_OWNER", "PROJECT_NUMBER", "GITHUB_REPOSITORY")}
    for k, v in env.items():
        if not v:
            fail(f"defina {k}")
    owner_type = os.environ.get("OWNER_TYPE", "user")
    if owner_type not in ("user", "organization"):
        fail("OWNER_TYPE deve ser 'user' ou 'organization'")

    items, suggestions = parse_roadmap(args.file)
    total = sum(1 + len(i.children) for i in items)
    log(f"{args.file}: {total} itens ({len(items)} principais) e {len(suggestions)} sugestões")
    log("modo: " + ("APLICAR (grava no GitHub)" if args.apply else "simulação (use --apply para gravar)"))

    gh = GitHub(env["GITHUB_REPOSITORY"], env["PROJECT_OWNER"], int(env["PROJECT_NUMBER"]), owner_type, args.apply)
    by_key, by_title = gh.existing_issues()
    drafts = gh.existing_drafts()

    stats = {"criadas": 0, "existentes": 0, "sugestões criadas": 0, "sugestões existentes": 0}
    pending_status = []
    import_items(gh, items, by_key, by_title, stats, pending_status)

    log("Sugestões (Draft Issues)")
    for title in suggestions:
        if title in drafts:
            log(f"= já existe: {title}")
            stats["sugestões existentes"] += 1
        elif not args.apply:
            log(f"+ [simulação] {title} | status={COL_SUGGESTION}")
            stats["sugestões criadas"] += 1
        else:
            item_id = gh.create_draft(title, "Importada do `ROADMAP.md` (Sugestões).")
            gh.set_option(item_id, STATUS_FIELD, gh.option(STATUS_FIELD, COL_SUGGESTION))
            pending_status.append((title, item_id, COL_SUGGESTION))
            log(f"+ {title} | status={COL_SUGGESTION}")
            stats["sugestões criadas"] += 1

    if args.apply:
        verify_status(gh, pending_status)
    verb = "" if args.apply else " (simulação)"
    log("Resumo" + verb + ": " + ", ".join(f"{k}={v}" for k, v in stats.items()))


if __name__ == "__main__":
    main()
