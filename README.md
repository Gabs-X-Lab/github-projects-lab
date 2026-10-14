# GitHub Projects Lab

Laboratório para estudar **GitHub Projects (V2)** e **GitHub Actions** como substituto de um roadmap mantido manualmente em markdown.

Fluxo alvo do Kanban:

```
Sugestão → Backlog → To Do → In Progress → Draft PR → In Review → Approved → Done
```

- A **Issue** é o card principal da funcionalidade.
- O **Pull Request** é vinculado à Issue (`Closes #N`), sem gerar card duplicado.
- O Project é atualizado automaticamente por workflows nativos e GitHub Actions.

## Arquivos

| Arquivo | Conteúdo |
|---|---|
| [`PLANO-LAB.md`](PLANO-LAB.md) | Análise, arquitetura, permissões e plano em etapas |
| [`docs/MANUAL-LAB.md`](docs/MANUAL-LAB.md) | Manual reproduzível: conceitos, passo a passo, comandos, descobertas e decisões |
| [`ROADMAP.md`](ROADMAP.md) | Roadmap fictício (projeto "Agendaí") usado como dados de migração |
